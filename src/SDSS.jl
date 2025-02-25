module SDSS

import DataFrames
import FITSIO
import Grid
import WCS

import ..PSF

const band_letters = ['u', 'g', 'r', 'i', 'z']

const default_mask_planes = Set(
    ["S_MASK_INTERP", "S_MASK_SATUR", "S_MASK_CR", "S_MASK_GHOST"])

function load_stamp_catalog_df(cat_dir, stamp_id, blob; match_blob=false)
    # These files are generated by
    # https://github.com/dstndstn/tractor/blob/master/projects/inference/testblob2.py
    cat_fits = FITSIO.FITS("$cat_dir/cat-$stamp_id.fits")
    num_cols = FITSIO.read_key(cat_fits[2], "TFIELDS")[1]
    ttypes = [FITSIO.read_key(cat_fits[2], "TTYPE$i")[1] for i in 1:num_cols]

    df = DataFrames.DataFrame()
    for i in 1:num_cols
        tmp_data = read(cat_fits[2], ttypes[i])
        df[symbol(ttypes[i])] = tmp_data
    end

    close(cat_fits)

    if match_blob
        camcol_matches = df[:camcol] .== blob[3].camcol_num
        run_matches = df[:run] .== blob[3].run_num
        field_matches = df[:field] .== blob[3].field_num
        df = df[camcol_matches & run_matches & field_matches, :]
    end

    df
end



"""
Load data from a psField file, which contains the point spread function.

Args:
 - field_dir: The directory of the file
 - run_num: The run number
 - camcol_num: The camcol number
 - field_num: The field number
 - b: The filter band (a number from 1 to 5)

Returns:
 - RawPSFComponents.

The point spread function is represented as an rnrow x rncol image
showing what a true point source would look as viewed through the optics.
This image varies across the field, and to parameterize this variation,
the PSF is represented as a linear combination of four "eigenimages",
with weights that vary across the image.  See get_psf_at_point()
for more details.
"""
function load_psf_data(field_dir, run_num, camcol_num, field_num, b)
    @assert 1 <= b <= 5
    psf_filename = "$field_dir/psField-$run_num-$camcol_num-$field_num.fit"
    psf_fits = FITSIO.FITS(psf_filename)
    psf_hdu = psf_fits[b + 1]

    nrows = FITSIO.read_key(psf_hdu, "NAXIS2")[1]
    nrow_b = read(psf_hdu, "nrow_b")[1]
    ncol_b = read(psf_hdu, "ncol_b")[1]
    rnrow = read(psf_hdu, "rnrow")[1]
    rncol = read(psf_hdu, "rncol")[1]
    cmat = convert(Array{Float64, 3}, read(psf_hdu, "c"))
    rrows = convert(Array{Float64, 2}, reduce(hcat, read(psf_hdu, "rrows")))
    close(psf_fits)

    # Only the first (nrow_b, ncol_b) submatrix of cmat is used for reasons obscure
    # to the author.
    PSF.RawPSFComponents(rrows, rnrow, rncol, cmat[1:nrow_b, 1:ncol_b, :])
end


"""
Load relevant data from a photoField file.

Args:
 - field_dir: The directory of the file
 - run_num: The run number
 - camcol_num: The camcol number
 - field_num: The field number
 - b: The filter band id (a number from 1 to 5)

Returns:
 - band_gain: An array of gains for the five bands
 - band_dark_variance: An array of dark variances for the five bands
"""
function load_photo_field(field_dir, run_num, camcol_num, field_num)
    pf_filename = "$field_dir/photoField-$run_num-$camcol_num.fits"
    pf_fits = FITSIO.FITS(pf_filename)
    @assert length(pf_fits) == 2

    field_num_int = parse(Int, field_num)
    field_row = read(pf_fits[2], "field") .== field_num_int
    band_gain = collect(read(pf_fits[2], "gain")[:, field_row])
    band_dark_variance = collect(read(pf_fits[2], "dark_variance")[:, field_row])

    close(pf_fits)

    band_gain, band_dark_variance
end


"""
Load the raw electron counts, calibration vector, and sky background from a field.

Args:
 - field_dir: The directory of the file
 - run_num: The run number
 - camcol_num: The camcol number
 - field_num: The field number
 - b: The filter band (a number from 1 to 5)
 - gain: The gain for this band (e.g. as read from photoField)

Returns:
 - nelec: An image of raw electron counts in nanomaggies
 - calib_col: A column of calibration values (the same for every column of the image)
 - sky_grid: A CoordInterpGrid bilinear interpolation object
 - sky_x: The x coordinates at which to evaluate sky_grid to match nelec.
 - sky_y: The y coordinates at which to evaluate sky_grid to match nelec.
 - sky_image: The sky interpolated to the original image size.
 - wcs: A WCS.WCSTransform object for convert between world and pixel
   coordinates.

The meaing of the frame data structures is thoroughly documented here:
http://data.sdss3.org/datamodel/files/BOSS_PHOTOOBJ/frames/RERUN/RUN/CAMCOL/frame.html
"""
function load_raw_field(field_dir, run_num, camcol_num, field_num, b, gain)
    @assert 1 <= b <= 5
    b_letter = band_letters[b]

    img_filename = "$field_dir/frame-$b_letter-$run_num-$camcol_num-$field_num.fits"
    img_fits = FITSIO.FITS(img_filename)
    @assert length(img_fits) == 4

    # This is the sky-subtracted and calibrated image.
    processed_image = read(img_fits[1])

    # Read in the sky background.
    sky_image_raw = read(img_fits[3], "ALLSKY")
    sky_x = collect(read(img_fits[3], "XINTERP"))
    sky_y = collect(read(img_fits[3], "YINTERP"))

    # Get the WCS coordinates.
    header_str = FITSIO.read_header(img_fits[1], ASCIIString)
    wcs = WCS.from_header(header_str)[1]

    # These are the column types (not currently used).
    ctype = [FITSIO.read_key(img_fits[1], "CTYPE1")[1],
             FITSIO.read_key(img_fits[1], "CTYPE2")[1]]

    # This is the calibration vector:
    calib_col = read(img_fits[2])
    calib_image = [ calib_col[row] for
                    row in 1:size(processed_image)[1],
                    col in 1:size(processed_image)[2] ]

    close(img_fits)

    # Interpolate the sky to the full image.  Combining the example from
    # http://data.sdss3.org/datamodel/files/BOSS_PHOTOOBJ/frames/RERUN/RUN/CAMCOL/frame.html
    # ...with the documentation from the IDL language:
    # http://www.exelisvis.com/docs/INTERPOLATE.html
    # ...we can see that we are supposed to interpret a point (sky_x[i], sky_y[j])
    # with associated row and column (if, jf) = (floor(sky_x[i]), floor(sky_y[j]))
    # as lying in the square spanned by the points
    # (sky_image_raw[if, jf], sky_image_raw[if + 1, jf + 1]).
    # ...keeping in mind that IDL uses zero indexing:
    # http://www.exelisvis.com/docs/Manipulating_Arrays.html
    sky_grid_vals = ((1:1.:size(sky_image_raw)[1]) - 1, (1:1.:size(sky_image_raw)[2]) - 1)
    sky_grid = Grid.CoordInterpGrid(sky_grid_vals, sky_image_raw[:,:,1],
                                    Grid.BCnearest, Grid.InterpLinear)

    # This interpolation is really slow.
    sky_image = [ sky_grid[x, y] for x in sky_x, y in sky_y ]

    # Convert to raw electron counts.  Note that these may not be close to integers
    # due to the analog to digital conversion process in the telescope.
    nelec = gain * convert(Array{Float64, 2}, (processed_image ./ calib_image .+ sky_image))

    nelec, calib_col, sky_grid, sky_x, sky_y, sky_image, wcs
end


"""
Set the pixels in mask_img to NaN in the places specified by the fpM file.

Args:
 - mask_img: The image to be masked (updated in place)
 - field_dir: The directory of the file
 - run_num: The run number
 - camcol_num: The camcol number
 - field_num: The field number

Returns:
 - Updates mask_img in place by setting to NaN all the pixels specified.

 This is based on the function setMaskedPixels in astrometry.net:
 https://github.com/dstndstn/astrometry.net/
"""
function mask_image!(mask_img, field_dir, run_num, camcol_num, field_num, band;
                     python_indexing = false,
                     mask_planes = default_mask_planes)
    # The default mask planes are those used by Dustin's astrometry.net code.
    # See the comments in sdss/dr8.py for fpM.setMaskedPixels
    # and the function sdss/common.py:fpM.setMaskedPixels
    #
    # interp = pixel was bad and interpolated over
    # satur = saturated
    # cr = cosmic ray
    # ghost = artifact from the electronics.

    # http://data.sdss3.org/datamodel/files/PHOTO_REDUX/RERUN/RUN/objcs/CAMCOL/fpM.html
    band_letter = band_letters[band]
    fpm_filename = "$field_dir/fpM-$run_num-$band_letter$camcol_num-$field_num.fit"
    fpm_fits = FITSIO.FITS(fpm_filename)

    # The last header contains the mask.
    fpm_mask = fpm_fits[12]
    fpm_hdu_indices = read(fpm_mask, "value")

    # Only these rows contain masks.
    masktype_rows = find(read(fpm_mask, "defName") .== "S_MASKTYPE")

    # Apparently attributeName lists the meanings of the HDUs in order.
    mask_types = read(fpm_mask, "attributeName")
    plane_rows = findin(mask_types[masktype_rows], mask_planes)

    # Make sure each mask is present.  Is this check appropriate for all mask files?
    @assert length(plane_rows) == length(mask_planes)

    for fpm_i in plane_rows
        # You want the HDU in 2 + fpm_mask.value[i] for i in keep_rows (in a 1-indexed language).
        mask_index = 2 + fpm_hdu_indices[fpm_i]
        cmin = read(fpm_fits[mask_index], "cmin")
        cmax = read(fpm_fits[mask_index], "cmax")
        rmin = read(fpm_fits[mask_index], "rmin")
        rmax = read(fpm_fits[mask_index], "rmax")
        row0 = read(fpm_fits[mask_index], "row0")
        col0 = read(fpm_fits[mask_index], "col0")

        @assert all(col0 .== 0)
        @assert all(row0 .== 0)
        @assert length(rmin) == length(cmin) == length(rmax) == length(cmax)

        for block in 1:length(rmin)
            # The ranges are for a 0-indexed language.
            @assert cmax[block] + 1 <= size(mask_img)[1]
            @assert cmin[block] + 1 >= 1
            @assert rmax[block] + 1 <= size(mask_img)[2]
            @assert rmin[block] + 1 >= 1

            # Some notes:
            # See astrometry.net//sdss/common.py:SetMaskedPixels, which I believe
            # is currently incorrect.
            # - In contrast with  julia, the numpy matrix index range [3:5, 3:5] contains four
            #   pixels, not six.  However, if the numpy is correct, then fpM files contain
            #   many bad rows that don't get masked at all since cmin == cmax
            #   or rmin == rmax.  For this reason, I think the python might be erroneous.
            # - For some reason, the sizes are inconsistent if the rows are read first.
            #   I presume that either these names are strange or I am supposed to read
            #   the image from the field and transpose it.
            # - Julia is 1-indexed, not 0-indexed.

            # Give the option of using Dustin's python indexing or not.
            if python_indexing
                mask_rows = (cmin[block] + 1):(cmax[block])
                mask_cols = (rmin[block] + 1):(rmax[block])
            else
                mask_rows = (cmin[block] + 1):(cmax[block] + 1)
                mask_cols = (rmin[block] + 1):(rmax[block] + 1)
            end

            mask_img[mask_rows, mask_cols] = NaN
        end
    end
    close(fpm_fits)
end

"""
Read a catalog entry.

Args:
 - field_dir: The directory of the file
 - run_num: The run number
 - camcol_num: The camcol number
 - field_num: The field number
 - bandnum: The band number from which to read galaxy properties.  Defaults
    to 3, the r band

Returns:
 - A data frame containing catalog entries in the rows.

 The data format is documented here:
 http://data.sdss3.org/datamodel/files/BOSS_PHOTOOBJ/RERUN/RUN/CAMCOL/photoObj.html

 This is based on the function get_sources in tractor/sdss.py:
 https://github.com/dstndstn/tractor/
"""
function load_catalog_df(field_dir, run_num, camcol_num, field_num; bandnum=3)

    cat_filename = "$field_dir/photoObj-$run_num-$camcol_num-$field_num.fits"
    cat_fits = FITSIO.FITS(cat_filename)

    cat_hdu = cat_fits[2]

    # Eliminate "bright" objects.
    # photo_flags1_map is defined in astrometry.net/sdss/common.py
    # ...where we see that photo_flags1_map['BRIGHT'] = 2
    const bright_bitmask = 2
    is_bright = read(cat_hdu, "objc_flags") & bright_bitmask .> 0
    has_child = read(cat_hdu, "nchild") .> 0

    # This is the position.  In tractor, it is passed into tractor:RaDecPos(ra, dec)
    objid = read(cat_hdu, "objid");
    ra = read(cat_hdu, "ra")
    dec = read(cat_hdu, "dec")

    # 6 = star, 3 = galaxy, others can be ignored.
    objc_type = read(cat_hdu, "objc_type");
    is_star = objc_type .== 6
    is_gal = objc_type .== 3
    is_bad_obj = !(is_star | is_gal)

    # Read in the galaxy types.
    fracdev = read(cat_hdu, "fracdev")[bandnum, :][:];
    has_dev = fracdev .> 0.
    has_exp = fracdev .< 1.
    is_comp = has_dev & has_exp
    is_bad_fracdev = (fracdev .< 0.) | (fracdev .> 1)

    # Read the fluxes.
    psfflux = read(cat_hdu, "psfflux")

    # Record the cmodelflux if the galaxy is composite, otherwise use
    # the flux for the appropriate type.
    cmodelflux = read(cat_hdu, "cmodelflux")
    devflux = read(cat_hdu, "devflux")
    expflux = read(cat_hdu, "expflux")

    # Only collect the following properties for a particular band.
    # NB: the phi quantites in tractor are multiplied by -1.
    phi_dev_deg = read(cat_hdu, "phi_dev_deg")[bandnum, :][:]
    phi_exp_deg = read(cat_hdu, "phi_exp_deg")[bandnum, :][:]

    theta_dev = read(cat_hdu, "theta_dev")[bandnum, :][:]
    theta_exp = read(cat_hdu, "theta_exp")[bandnum, :][:]

    ab_exp = read(cat_hdu, "ab_exp")[bandnum, :][:]
    ab_dev = read(cat_hdu, "ab_dev")[bandnum, :][:]

    close(cat_fits)

    # Match the column names in the stamp-making script.
    cat_df = DataFrames.DataFrame(objid=objid, ra=ra, dec=dec,
                                  is_star=is_star, is_gal=is_gal, frac_dev=fracdev,
                                  ab_exp=ab_exp, theta_exp=theta_exp, phi_exp=phi_exp_deg,
                                  ab_dev=ab_dev, theta_dev=theta_dev, phi_dev=phi_dev_deg)

    cat_df[:run] = run_num
    cat_df[:camcol] = camcol_num
    cat_df[:field] = field_num

    for b=1:length(band_letters)
        band_letter = band_letters[b]
        cat_df[symbol(string("psfflux_", band_letter))] = psfflux[b, :][:]
        cat_df[symbol(string("compflux_", band_letter))] = cmodelflux[b, :][:]
        cat_df[symbol(string("expflux_", band_letter))] = expflux[b, :][:]
        cat_df[symbol(string("devflux_", band_letter))] = devflux[b, :][:]
    end

    is_bad = is_bad_fracdev | is_bad_obj | is_bright | has_child
    bad_frac = sum(is_bad) / length(objid)
    println("Proportion of bad rows: $bad_frac")
    cat_df = cat_df[!is_bad, :]

    cat_df
end


end
